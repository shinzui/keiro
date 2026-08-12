---
id: 37
slug: fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review
title: "Fix the keiro runtime and operational defects surfaced by the pre-0.12 release review"
kind: master-plan
created_at: 2026-08-11T23:37:12Z
intention: "intention_01kzsjzp13e28vvrz7jfdve3dt"
---

# Fix the keiro runtime and operational defects surfaced by the pre-0.12 release review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The 2026-08-11 pre-release review (a multi-agent, adversarially verified review of every
change since the `keiro-*-0.11.0.0` tags at `e796227c`) confirmed seven runtime and
operational correctness defects and three defect-risk quality findings in the `keiro` and
`keiro-ops` packages. The 0.12.0.0 release is the first stable release and the start of fleet
adoption, and the user's directive is explicit: no known bugs ship.

After this MasterPlan completes: a projection catalog can evolve after registration — adding
a read model or group no longer permanently locks a deployed service out of registration and
rebuild, and the catalog fingerprint that gates those refusals is computed from an
injection-proof canonical encoding; Strong-consistency read-model queries no longer stall
forever after workflow garbage collection hard-deletes the newest events; cancelling an
awakeable can no longer race a concurrent suspend into a permanently undiscoverable workflow,
and the documented drain-until-zero resume contract actually terminates; deterministic
command/awakeable ids computed from non-ASCII seeds still deduplicate against dispatches made
before the UTF-8 encoding switch; `keiro-ops` rejects non-finite (`NaN`/`Infinity`) durations
before they turn a forced garbage-collection pass into unbounded deletion; and the
correctness-critical dispatch, retry, and rebuild-paging logic that the review found
copy-pasted across legacy/domain and Router/ProcessManager paths is consolidated so future
fixes land once.

Excluded: every keiro-dsl language-surface defect (those are
`docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`);
release mechanics (version bumps, changelogs, tags, the language-5 registry flip); and the
pre-existing open reliability backlog (MasterPlans 17, 18, 20, 22 and the improvement-request
queue), which ships in follow-up releases as originally intended.


## Decomposition Strategy

The ten review findings group into six work streams by functional concern. EP-1 merges the
two catalog-fingerprint findings (the injectable preimage and the never-refreshed stored
fingerprint) because they are one design problem: changing the canonical encoding changes
every fingerprint, so the encoding fix and the evolution/adoption path must ship as one
atomic change — separately, the first would trigger exactly the lockout the second exists to
remedy. EP-3 merges the cancel-versus-suspend race with the false drain contract because both
live in the workflow lifecycle/discovery surface governed by the same two ADRs and are
verified by the same style of interleaving test. EP-6 collects the three quality findings
(duplicated command retry skeletons, duplicated router/process-manager dispatch logic,
rebuild read amplification) into one behavior-preserving consolidation wave: none is a live
bug, all are "the next fix lands in only one copy" risks, and their acceptance is identical —
tests stay green, outputs unchanged, plus benchmark evidence for the paging fix. EP-2, EP-4,
and EP-5 are single-finding plans with disjoint surfaces. Merging EP-2 into EP-1 was rejected
(different subsystem: consistency waits versus catalog identity); splitting EP-6 three ways
was rejected (three trivial plans editing adjacent code that EP-4 also constrains).

Relevant ADRs, read during planning:
`docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md` and
`docs/adr/0027-workflow-lifecycle-markers-are-append-only-and-first-writer-wins.md` (the race
discipline EP-3 must restore for cancellation),
`docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`
(why a wrong suspended row now strands forever — the regression EP-3 closes),
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`
(the encoding switch EP-4 bridges; EP-4 updates this ADR),
`docs/adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md`
(the pass-reporting contract EP-3's drain fix extends),
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md` and
`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
(the identity and checkpoint semantics EP-1 and EP-2 must preserve), and
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
(why EP-1's remediation path must be a supported library API surfaced through keiro-ops, and
the ownership rule EP-5's CLI hardening serves). No cross-repository ADR applies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Canonicalize catalog fingerprint preimages and support catalog evolution | docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md | None | None | Complete |
| 2 | Target strong-consistency waits at the visible store head | docs/plans/238-target-strong-consistency-waits-at-the-visible-store-head.md | None | None | Complete |
| 3 | Close the awakeable cancel-versus-suspend race and fix the drain contract | docs/plans/239-close-the-awakeable-cancel-versus-suspend-race-and-fix-the-drain-contract.md | None | None | Complete |
| 4 | Bridge deterministic-id deduplication across the UTF-8 encoding upgrade | docs/plans/240-bridge-deterministic-id-deduplication-across-the-utf-8-encoding-upgrade.md | None | None | Complete |
| 5 | Reject non-finite durations in keiro-ops destructive commands | docs/plans/241-reject-non-finite-durations-in-keiro-ops-destructive-commands.md | None | None | Complete |
| 6 | Deduplicate dispatch and retry skeletons and fix rebuild read amplification | docs/plans/242-deduplicate-dispatch-and-retry-skeletons-and-fix-rebuild-read-amplification.md | None | EP-1, EP-4 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 through EP-5 are mutually independent and can proceed in parallel; they touch disjoint
modules. EP-6 carries two soft dependencies. On EP-4: EP-6 consolidates the router and
process-manager dispatch paths whose dual dedup probe (current-encoding id plus legacy id)
EP-4 is redefining — consolidating after EP-4 means the bridged probe is written once in the
shared helper rather than fixed in four copies; consolidating first is acceptable only if
EP-4 then lands entirely inside the shared helper. On EP-1: EP-6's rebuild-paging milestone
edits `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`, the same module whose `rebuildContract`
preimage EP-1 canonicalizes; the functions are different, so this is merely a rebase-order
preference, EP-1 first.

Release sequencing: EP-1 must land before any external adopter registers a catalog whose
fingerprint would persist, which in practice means before the 0.12.0.0 tag — the canonical
encoding change alters every fingerprint, and 0.12 is the last point where no supported
deployment has persisted one. All six plans are expected to complete before the release per
the Decision Log; EP-6 is the only one whose deferral would not ship a known bug.


## Integration Points

The canonical fingerprint encoding is owned by EP-1 and applies in two places: the catalog
inventory preimage in `keiro/src/Keiro/Projection/Catalog.hs` (`renderInventory`) and the
rebuild-resume contract in `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` (`rebuildContract`).
EP-1 defines one shared encoding helper and converts both call sites; EP-6's rebuild-paging
milestone touches the same module afterward and must not alter the contract computation.

The idempotent-dispatch probe pair (current deterministic id plus legacy-encoding id) is
redefined by EP-4 in `keiro/src/Keiro/Router.hs`, `keiro/src/Keiro/ProcessManager.hs`, and
`keiro/src/Keiro/Workflow/Awakeable.hs`. EP-6 consolidates the copies of that probe logic
into one helper; whichever plan lands second must preserve the other's semantics, and the
end state is one shared helper containing the bridged probe.

The `keiro-ops` surface is touched by EP-3 (its workflow commands call
`resumeWorkflowsOnceUpTo` through `keiro-ops/src/Keiro/Ops/Workflow.hs` and consume the
pass-result shape EP-3 changes), EP-5 (duration parsing in
`keiro-ops/src/Keiro/Ops/Parse.hs`, plus numeric-reader consolidation across the command
modules including `Workflow.hs`), and EP-1 (the new `rebuild adopt` command). EP-3 and EP-5
both edit `keiro-ops/src/Keiro/Ops/Workflow.hs` in disjoint regions (resume output shape
versus flag readers); no ordering constraint, but whichever lands second rebases trivially.

Cross-plan decisions expected to become ADR updates: EP-1's canonical fingerprint encoding
and its catalog-evolution/adoption semantics belong in
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
and `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
(or a new ADR if the evolution policy warrants its own record); EP-4's legacy-dedup bridge
window and its removal criteria belong in
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`;
EP-3's honest pass-reporting shape extends
`docs/adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md`.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (237) M1: prototyping — both defects reproduced, encoder injectivity and lifecycle-join map validated against the real schema (2026-08-12T11:04:39Z)
- [x] EP-1 (237) M2: pure canonical encoding (`Keiro.Projection.Catalog.Preimage`, `catalog-v2:`/`slice-v1:`) with the two collision fixtures as regressions (2026-08-12T11:11:51Z)
- [x] EP-1 (237) M3: slice-scoped group identity (`slice-v1:`, migration 0024) — additive catalog changes register cleanly, changed/stale slices refused with typed errors (2026-08-12T11:27:41Z)
- [x] EP-1 (237) M4: transactional `previewCatalogAdoption`/`adoptCatalogGroups` library API (2026-08-12T11:46:09Z)
- [x] EP-1 (237) M5: `keiro-ops rebuild adopt` with preview-then---force (2026-08-12T11:47:46Z)
- [x] EP-1 (237) M6: docs, changelogs, ADR 0032 and pointer amendments to ADRs 0026/0028/0031, full `just verify` (2026-08-12T12:05:34Z)
- [x] EP-2 (238) M1: reproduce-first GC regression test plus the visible-head fix in ReadModel.hs, with genuine-behind timeout non-regression (2026-08-12T16:55:27Z)
- [x] EP-2 (238) M2: distance gauge rebased to the visible head; zero-after-GC metrics test (2026-08-12T17:00:29Z)
- [x] EP-2 (238) M3: keiro-ops dual-head columns with a store/visible divergence test (2026-08-12T17:03:19Z)
- [x] EP-2 (238) M4: api-reference/CHANGELOG updates, ADR 0033 plus ADR 0028 amendment, and full `just verify` (2026-08-12T17:15:51Z)
- [x] EP-2 (238) post-completion: adopt Kiroku 0.6's public visible-head effect and transactional statement, remove duplicate SQL, and advance workspace bounds (2026-08-12T18:51:10Z)
- [x] EP-2 (238) post-completion: focused read-model regressions and full `just verify` pass against Kiroku 0.6.0.0 (2026-08-12T19:08:43Z)
- [x] EP-3 (239) M1: cancel takes the per-step lock, suspend re-check consults awakeable status; both-order interleaving tests (2026-08-12T18:10:51Z)
- [x] EP-3 (239) M2: `ClaimOutcome` and `ResumeSummary` reshape (`advanced`/`paced`/`unregisteredNames`); drain-termination test (2026-08-12T18:20:18Z)
- [x] EP-3 (239) M3: keiro-ops `wf resume-once` surface and tests (2026-08-12T18:23:05Z)
- [x] EP-3 (239) M4: CHANGELOG, ADR 0023/0025 amendments, masterplan bookkeeping (2026-08-12T18:39:59Z)
- [x] EP-4 (240): implementation complete (2026-08-12T19:43:22Z)
- [x] EP-4 (240) M1: frozen legacy encoder pinned by golden vectors captured at `f8ca7a16^` (2026-08-12T19:17:05Z)
- [x] EP-4 (240) M2: `firstExistingEventId`/`deterministicCommandIdProbes` bridge all six dispatch probe sites, tests-first (2026-08-12T19:29:46Z)
- [x] EP-4 (240) M3: awakeable adoption bridge (2026-08-12T19:32:44Z)
- [x] EP-4 (240) M4: ADR 0024 window contract, CHANGELOG note, comment/window unification, and full Haskell gate (2026-08-12T19:43:22Z)
- [x] EP-5 (241): implementation complete (2026-08-12T19:52:30Z)
- [x] EP-5 (241) M1: `parseDuration` rejects non-finite/negative/beyond-wire-bound with frozen messages and a unit matrix (2026-08-12T19:46:50Z)
- [x] EP-5 (241) M2: integer readers consolidated and bounds-checked (3 `option auto` sites, 16 `reads` copies) (2026-08-12T19:49:52Z)
- [x] EP-5 (241) M3: executable-level no-DB-contact rejection test, ADR 0028 distillation, and full 38-example keiro-ops suite (2026-08-12T19:52:30Z)
- [x] EP-6 (242): implementation started after complete child-plan read; EP-1/EP-4 soft dependencies satisfied (2026-08-12T19:54:01Z)
- [x] EP-6 (242) M1: shared internal attempt loops (`domainCommandAttempts`/`domainSqlCommandAttempts`) collapse four retry loops to two with telemetry unchanged; full Haskell and command benchmark gates pass (2026-08-12T20:00:44Z)
- [x] EP-6 (242) M2 (after EP-4): router/PM dispatch consolidated onto the bridged probe helper; bridge, benign-duplicate, full Haskell, and fan-out benchmark gates green (2026-08-12T20:06:23Z)
- [x] EP-6 (242) M3 (after EP-1): buffered rebuild paging reduced the 3×6/page-2
      proof from 26 reads/48 returned rows to 11 reads/18 rows; the identical 3×200
      benchmark improved from 61.7 ms to 45.9 ms; full Haskell gate green
      (2026-08-12T20:45:22Z)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Plan-creation research (2026-08-11), EP-1: an abandoned (`failed`) rebuild group has no
  library path back to `live` — adjacent to but out of scope for plan 237; recorded there
  as a candidate improvement request to file.
- Plan-creation research (2026-08-11), EP-4: the review's é/i example is not a real
  mod-256 collision; verified colliding pairs include U+0101/U+0001 and U+4E2D/'-'. Also,
  the router's pre-existing `legacyCommandId` probe targets positional ids that all predate
  the UTF-8 change, so it switches to the frozen legacy encoder outright rather than
  gaining a third probe.
- EP-4 implementation (2026-08-12): all four historical command-ID reproductions
  doubled their planted streams before the bridge, and the historical awakeable row was
  bypassed for a fresh v4 allocation. After the six dispatch probes and generation-0
  adoption were bridged, the exact same scenarios retained one row and reported the
  captured historical identities. ASCII probe lists remain singleton.
- Plan-creation research (2026-08-11), EP-5: the defect is broader than one reader — 20
  numeric readers across keiro-ops include 3 unguarded `option auto` sites and 16 `reads`
  copies that wrap out-of-range literals mod 2^64; and the NaN cutoff collapses to exactly
  `now` on the wire (astronomical component divisible by 2^64), so a forced gc-sent pass
  deletes every sent row. Finite durations above ~9.22e12 seconds wrap the same way, which
  added a wire-representability bound to the guard.
- Plan-creation research (2026-08-11), EP-6: wrapping the public domain runners would leak
  `keiro.command.decision` span attributes into legacy entry points (pinned by existing
  telemetry tests), so the consolidation extracts shared internal attempt loops instead.
  Two review details corrected: `keiro/src/Keiro/Projection.hs:288` duplicates the
  catalog-fence callback pair, not a fifth retry loop; and the second amplification site is
  the quadratic `eventConsumed`/`completedSources` rescan inside `applyChunkTx`.
- EP-1 M2 implementation (2026-08-12): the aggregate checklist mislabeled
  `contract-v2:` as an M2 output. The child plan correctly assigns the rebuild
  contract switch to M3, where its persisted run schema and epoch joins change;
  the checklist now names M2's actual `slice-v1:` output.
- EP-1 M3 implementation (2026-08-12): `Runner.hs` now persists and joins on the
  group slice independently from whole-catalog provenance. This is the surface
  EP-6 M3 must preserve while removing the rebuild paging rescan; additive catalog
  registration and active-run resume now pass without weakening genuine slice
  drift fences.
- EP-1 M6 verification (2026-08-12): the persistent Jitsurei development database
  contained a real pre-canonical registration row. Migration 0024 deliberately
  preserved it as stale evidence; the new supported adoption preview classified it,
  `rebuild adopt --force` reconciled it, and the full `just verify` then passed.
  This exercised the documented unreleased-snapshot cutover without direct SQL.
- EP-2 post-completion (2026-08-12): Kiroku published 0.6.0.0 with the public
  visible-global-head effect and transaction-composable statement requested by this
  work. Hackage, upstream tag `kiroku-store-v0.6.0.0`, and Mori-located source agree;
  Keiro now delegates both call sites and requires `kiroku-store >=0.6 && <0.7`.
- EP-6 M3 implementation (2026-08-12): retaining per-source page tails eliminated
  duplicate event fetches without weakening the fixed-head replay contract. Exact
  expected-cursor updates condemn a stale chunk and force a fresh inspection, so
  concurrent-driver interference falls back to the old safe behavior instead of
  double-applying a retained tail.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Split the pre-release fixes into two MasterPlans — runtime/operational defects
  here, language-surface defects in
  `docs/masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md`.
  Rationale: User direction. This set has no language-contract coupling; its gate is the
  user's no-known-bugs bar for the 0.12.0.0 release rather than the language-5 publication
  flip.
  Date: 2026-08-11
- Decision: The fingerprint-encoding fix and the catalog-evolution path are one plan (EP-1),
  not two.
  Rationale: The encoding change alters every fingerprint; without an evolution/adoption path
  landing atomically, the fix itself would trigger the permanent lockout it is meant to
  prevent. Ordering them as separate plans would create a window where the system is worse
  than before either.
  Date: 2026-08-11
- Decision: All six child plans are in scope for the release; EP-6 is marked as the only one
  whose deferral would not ship a known bug.
  Rationale: User directive that no known bugs ship covers EP-1 through EP-5 (confirmed
  correctness defects). EP-6's findings are defect-risk duplication and read amplification —
  real, verified, but not live bugs; it is scheduled last and its deferral is a release-time
  judgment call recorded here so it is a conscious one.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 is complete. It replaced injectable catalog and replay-contract preimages with
canonical versioned encodings, narrowed lifecycle equality gates from the whole
catalog to each rebuild group's owned slice, and added explicit transactional
metadata adoption through the library and `keiro-ops`. Unrelated additions no
longer lock existing groups or interrupted runs, while genuine group drift remains
refused until an operator previews and forces adoption. ADR 0032 and amendments to
ADRs 0026, 0028, and 0031 capture the durable boundary, and full repository
verification passed.

EP-2 is complete. Strong whole-log reads now capture the newest visible event as a
reachable wait target, while genuinely behind subscriptions retain the honest timeout
path. Projection distance uses the same visible basis and `keiro-ops` reports both the
authoritative append counter and visible head. The workflow-GC, timeout, telemetry, and
operator divergence regressions pass; ADR 0033 and the ADR 0028 amendment preserve the
contract. Kiroku 0.6 now owns the visible-head effect and transaction-composable SQL,
so Keiro carries no duplicate schema query; full repository verification passed.

EP-3 is complete. Awakeable cancellation, signal delivery, and suspension now
share one per-step serialization discipline, and suspend arbitration consults
terminal awakeable state so neither cancellation commit order can strand an
exact-discovery workflow. Resume summaries distinguish the admitted pool from
durable advances and expose paced and unregistered blockers through the library
and `keiro-ops`; bounded drains now terminate on honest progress. ADRs 0023 and
0025 preserve both contracts, and full repository verification passed.

EP-4 is complete. The frozen pre-UTF-8 encoder is independently pinned, all six dispatch
preflights and generation-0 awakeable adoption consult historical identity, and ADR 0024
defines the unified operator-attested removal window; full Haskell verification passed.

EP-5 is complete. Destructive duration arguments are rejected before database access
when non-finite, negative, or outside the PostgreSQL timestamp wire range, and every
bounded integral argument is protected from machine-integer wraparound. Pure parser
coverage and an executable-level unreachable-database proof pass, the full 38-example
`keiro-ops-test` suite is green, and ADR 0028 records the durable safety boundary.

EP-6 is complete. Four command retry implementations now share two attempt loops without
changing public outcomes or telemetry; Router and ProcessManager command dispatch share
one bridged idempotency helper; and the rebuild runner retains source-page tails with an
expected-cursor interference guard. The counted replay proof fetches every event once
(48 returned rows before, 18 after), and the 3×200 benchmark is about 26% faster. The
final full Haskell matrix passed. No ADR was added: this consolidation changes no public
API, persisted format, identity, or operational contract.

The MasterPlan is complete. EP-1 removes the release-critical catalog lockout and
fingerprint-forgery defects; EP-2 removes the unreachable consistency target and
permanent false-distance defect; EP-3 removes the workflow-stranding race and
non-terminating drain contract; EP-4 removes deploy-boundary double dispatch and orphaned
awakeables for non-ASCII identity; EP-5 removes destructive numeric corruption before
operational preview or mutation; and EP-6 removes the duplicated correctness paths and
rebuild read amplification that made future fixes risky.

Revision note (2026-08-12): Completed EP-1, recorded its durable catalog-identity
and adoption decisions in ADR 0032 and related amendments; completed EP-2, recorded
reachable consistency targets in ADR 0033, amended ADR 0028, and adopted Kiroku 0.6's
public visible-head API; completed EP-3 and amended ADRs 0023 and 0025 with wake
arbitration and bounded-drain progress; completed EP-4 and amended ADR 0024 with the
golden-pinned compatibility bridge and its operator-attested removal criteria; completed
EP-5 with total duration and bounded integer parsing, an executable no-database-contact
proof, and the ADR 0028 amendment; completed EP-6 with shared retry/dispatch paths,
buffered rebuild paging, counted and wall-time performance evidence, and no new ADR
material; marked the MasterPlan complete.
