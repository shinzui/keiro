---
id: 39
slug: fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review
title: "Fix the catalog rebuild replay and adoption defects from the fix verification review"
kind: master-plan
created_at: 2026-08-12T23:55:22Z
intention: "intention_01kzw6dk7qe1qayx2qdz6vcqfd"
---

# Fix the catalog rebuild replay and adoption defects from the fix verification review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The 2026-08-12 follow-up verification review (an adversarially verified code review over
`39bc631c..HEAD`, the fifty-six commits that implemented MasterPlans 36–38) confirmed five
defects in the catalog rebuild pipeline — the subsystem those commits had just reworked
under `docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md`
and `docs/plans/242-deduplicate-dispatch-and-retry-skeletons-and-fix-rebuild-read-amplification.md`.
Two are silent-corruption bugs: the buffered replay pager introduced by plan 242 can apply
events out of global-position order across a multi-source rebuild group, and the canonical
resume contract introduced by plan 237 no longer captures replay-adapter application order,
so an interrupted rebuild can resume under a different adapter order than the half already
applied. Two are adoption-surface defects: the non-forced `keiro-ops rebuild adopt` preview
renders the whole-catalog plan while the forced execution adopts only the named groups, and
the adoption transaction silently no-ops query registrations that have no row while stranding
renamed registry rows forever. The fifth is an upgrade trap: migration
`keiro-migrations/migrations/0024.sql` stamps in-flight rebuild runs with the sentinel
`'$pre-canonical'`, which no resume, abandon, adoption, or registration path handles, so a
database that upgrades while a rebuild is `rebuilding` or `failed` becomes unrecoverable
through every supported API.

After this MasterPlan completes, a multi-source catalog rebuild provably applies events in
ascending global position across all sources under every paging boundary; resuming an
interrupted rebuild refuses when replay-adapter application order changed; a database
upgraded by 0024 mid-rebuild has a supported, documented recovery path that never requires
hand-written SQL; and the adoption operator surface previews exactly what it will execute
and reports exactly what it did, including registrations it could not adopt.

All child plans gate the 0.12.0.0 release (EP-5, the post-promotion async redelivery
fix confirmed on 2026-08-13, included): 0.12 is the first stable release, the
persisted fingerprint and run formats become compatibility surfaces at that tag, and the
rebuild protocol is the foundation MasterPlan 41 (out-of-process reader safety,
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`)
builds on. Explicitly excluded: the three runtime/DSL defects from the same review
(MasterPlan 40, `docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md`),
all IR-22 capabilities (MasterPlan 41), and release mechanics (version bumps, changelog
consolidation, the language-5 registry flip).


## Decomposition Strategy

The five review findings group into four work streams by functional concern; a fifth
work stream (EP-5) was added when the post-promotion redelivery defect was confirmed
after drafting — see Surprises & Discoveries. The two replay
correctness defects are separate plans even though both live in
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`: one changes how the pager buffers and merges
source pages (a pure control-flow fix with a property-style ordering proof), the other
changes what the persisted resume contract hashes (a persisted-identity change with a
mandatory prefix bump under ADR-32's rules). They are independently verifiable — the pager
fix is provable with an in-memory multi-source interleaving test, the contract fix with a
resume-refusal test — and merging them would couple a behavior fix to a format change.

The two adoption findings merge into one plan: the preview/execute scope mismatch and the
UPDATE-only silent no-op are both defects in the same adoption transaction and its operator
reporting, discovered at the same boundary, and a fix to one necessarily reshapes the result
types the other reports through. The 0024 recovery trap is its own plan because it changes
migration semantics and recovery policy rather than adoption behavior, and because ADR-32
explicitly anticipated ("Pre-canonical persisted values also need a supported clean-break
recovery path before the unreleased 0.12 format becomes stable") what plan 237 did not
deliver for in-flight runs.

Relevant ADRs, read during planning: `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(canonical preimages, slice-scoped lifecycle identity, mandatory prefix bumps, explicit
transactional adoption — EP-2, EP-3, and EP-4 all amend it),
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(the four catalog identities; rebuild groups own the deterministic order of targets),
`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
(replay-safety identity the resume contract protects), and
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
(keiro-ops must wrap library APIs — the recovery path in EP-3 must land as a library API
plus an ops wrapper, never as documented SQL). No cross-repository ADR bears on this
MasterPlan beyond ADR-26's already-cited `mori://shinzui/mori/okf/adrs/concepts/ADR-20`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Preserve cross-source global position order in buffered replay paging | docs/plans/246-preserve-cross-source-global-position-order-in-buffered-replay-paging.md | None | None | Complete |
| 2 | Capture replay adapter application order in the rebuild resume contract | docs/plans/247-capture-replay-adapter-application-order-in-the-rebuild-resume-contract.md | None | EP-1 | Complete |
| 3 | Give pre-canonical in-flight rebuild runs a supported recovery path | docs/plans/248-give-pre-canonical-in-flight-rebuild-runs-a-supported-recovery-path.md | None | EP-2 | Complete |
| 4 | Make catalog adoption scoped, truthful, and registry-complete | docs/plans/249-make-catalog-adoption-scoped-truthful-and-registry-complete.md | None | EP-3 | In Progress |
| 5 | Make catalog rebuild promotion redelivery-safe for async projections | docs/plans/258-make-catalog-rebuild-promotion-redelivery-safe-for-async-projections.md | None | EP-1, EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

No plan has a hard dependency; each fix compiles and is verifiable on its own. The soft
dependencies form a single recommended sequence — EP-1, EP-2, EP-3, EP-4 — chosen to
minimize merge friction and format churn rather than to express semantic requirements.

EP-2 after EP-1 because both edit the replay internals of
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` and their tests both extend
`keiro/test/ProjectionReplaySpec.hs`; landing the pager fix first gives the contract change
a stable baseline for its resume tests. EP-3 after EP-2 because EP-2 bumps the persisted
resume-contract prefix, and EP-3's recovery semantics must be written against the final
0.12 contract encoding rather than remediated twice. EP-4 after EP-3 because EP-3 may need
adoption (or a sibling recovery API) to operate on groups that are not `GroupLive`, and
EP-4 reshapes the adoption preview/result types; sequencing them lets EP-4 finalize the
operator-facing report over EP-3's extended semantics. If sessions run in parallel, EP-1
and EP-4 can proceed concurrently with low conflict risk (disjoint files except tests);
EP-2 and EP-3 should not run concurrently with their soft predecessors.

EP-5 (added 2026-08-13 after the post-promotion redelivery defect was confirmed) soft-
depends on EP-1 and EP-2 because its fix lands in the promotion transaction of the same
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` those plans edit; its statements in
`Group.hs` are disjoint from EP-3/EP-4's adoption surface. It gates the release like
its siblings. MasterPlan 41's plan 256 reuses EP-5's dedup-backfill and
checkpoint-advance helpers for the versioned cutover path — EP-5 defines them, plan
256 consumes them (recorded there as well).


## Integration Points

The replay runner (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`) is shared by EP-1 and
EP-2. EP-1 owns the paging/merge loop (buffer refill policy, `duplicatePosition` guard,
chunk assembly around line 433); EP-2 owns the contract functions (`rebuildContract` and
its preimage near line 826) and must not change merge behavior. Both add regression
groups to `keiro/test/ProjectionReplaySpec.hs`; EP-2 rebases its tests on EP-1's merged
loop if EP-1 has landed.

The adoption library surface (`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`:
`previewCatalogAdoption`, `adoptCatalogGroups`, `adoptTx`, the query-registration
statements) is shared by EP-3 and EP-4. EP-4 owns the final shape of the preview and
result types (per-group and per-registration outcomes, scope annotations); EP-3 owns the
lifecycle-state preconditions (which group states adoption or recovery may act on) and the
`'$pre-canonical'` semantics. If EP-3 introduces a dedicated recovery API instead of
extending adoption, it must still report through the same per-group outcome vocabulary
EP-4 defines, and whichever plan lands second reconciles.

The keiro-ops wrapper (`keiro-ops/src/Keiro/Ops/Rebuild.hs`) is touched by EP-3 (recovery
command or extension of `rebuild adopt`) and EP-4 (scoped preview rendering). Same
reconciliation rule: the operator-visible table format is defined by EP-4.

Persisted format changes must follow ADR-32's prefix-bump rule: EP-2 bumps the resume
contract prefix; EP-3 must not invent a second sentinel — it defines the terminal handling
of `'$pre-canonical'` once. Both amend
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
in the same change that alters the contract, per the ADR workflow.

Cross-MasterPlan: MasterPlan 41's versioned-rebuild plan
(`docs/plans/256-rebuild-into-versioned-targets-with-atomic-cutover.md`) hard-depends on
EP-1 and EP-2 here — it rewrites the same replay path and must build on corrected ordering
and a contract that pins adapter order.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (246) M0-M1: baseline + red staggered-fixture test proving out-of-order application (promoted trace `[1,2,3,8,4,7,9]`) that still promotes
- [x] EP-1 (246) M2: merge-horizon clamp + monotonic applied floor with typed invariant failures (`replay.global-position-regression`, `replay.buffer-horizon-stalled`)
- [x] EP-1 (246) M3: seeded multi-interleaving ordering sweep (18 deterministic cases)
- [x] EP-1 (246) M4-M5: read-count/benchmark evidence (read-count parity and 0.8% benchmark delta), changelog, docs, `just verify`
- [x] EP-2 (247) M1: red order-swap resume test (slice fingerprints byte-equal, resume wrongly proceeds)
- [x] EP-2 (247) M2: `contract-v4` preimage with ordered adapter identities, runner format v4, slice-scoped abandon with `CatalogRebuildSliceMismatch`
- [x] EP-2 (247) M3-M4: same-order/swap/from-scratch proofs; ADR-32 amendment, user docs, changelog, `just verify`
- [x] EP-3 (248) M1: red mid-rebuild-upgrade reproduction (migration-level shape pin + full refusal matrix)
- [x] EP-3 (248) M2: sentinel-aware abandon (`abandonPreCanonicalGroupRebuild`) + typed `CatalogRebuildRunPreCanonical` resume refusal
- [x] EP-3 (248) M3: adoption + fresh rebuild accept `failed`/stale-format groups; ADR-32/ADR-26 amendments
- [x] EP-3 (248) M4-M5: sentinel-aware ops inspect/status/preview, `group_slice` run column, transcript; docs, changelogs, `just verify`
- [ ] EP-4 (249) M1: red tests for renamed/added registration no-ops and unscoped preview
- [ ] EP-4 (249) M2: lookup-then-update-or-insert adoption, orphan old-name deletion under the three-part rule, per-registration result types
- [ ] EP-4 (249) M3: scope-annotated preview, preview-time not-in-catalog refusal, v2 report envelopes and tables
- [ ] EP-4 (249) M4: ADR-32 adoption-contract amendment, docs, changelogs, plan-248 vocabulary reconciliation, `just verify`
- [ ] EP-5 (258) M1: red promote-then-redeliver double-application tests (ClearBeforeReplay and PreserveAndReconcile, real subscription members + dedup key, non-idempotent handler)
- [ ] EP-5 (258) M2: exported `CatalogAsyncDedupSpec`/`catalogAsyncIdempotencyKeys` (membership mirrors `preparationFor`; plan 256 consumes)
- [ ] EP-5 (258) M3: promote-transaction dedup backfill (input paged outside the tx over the immutable range) + checkpoint advance to captured head; typed `CatalogRebuildPromotionCheckpointsMissing`; inline-only fast path
- [ ] EP-5 (258) M4: resume/fenced/multi-member/redeliver-twice matrix
- [ ] EP-5 (258) M5: ADR-31 amendment, doc corrections (both idempotency lines reframed as defense-in-depth), changelog, `just verify`


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Drafting research for EP-3 (2026-08-12) found the trap is wider than the review
  stated: a `failed` group has never been able to adopt or begin a fresh rebuild (the
  `GroupLive` guard predates the canonical-fingerprint work — present since the
  subsystem's first commit `8a670c10`), so even operators who followed the documented
  "abandon before upgrading" precondition are bricked. `keiro-ops rebuild status` and
  the non-forced abandon preview also fail today on pre-canonical rows
  (`CatalogOpsRunSliceMismatch`). EP-3's scope includes both.
- Drafting research for EP-2 confirmed the origin: plan 237's decision log claimed the
  slice covers "adapter identities and order", but the slice preimage sorts projection
  metadata — the claim was wrong at birth, which is why no review of plan 237's tests
  caught it.
- CONFIRMED (2026-08-13, dedicated adversarial verification after plan 256's author
  flagged it): the offline catalog rebuild double-applies every replayed event to
  async projection targets after promotion. `beginGroupRebuild` deletes the group's
  replayable async dedup rows and resets subscription checkpoints to `replayFrom`,
  but the catalog replay path applies events through raw `applyForReplay` adapters
  that never re-seed dedup (the only dedup insert in the codebase is on the live
  async path), and promotion touches neither checkpoints nor dedup — so a restarted
  worker redelivers the exact replayed range `(replayFrom, capturedHead]` and every
  handler runs twice. The legacy protocol deliberately preserved this invariant by
  replaying through `applyAsyncProjectionUnfenced` (its tests pin post-promotion
  value stability); the catalog runner reused the legacy preparation but dropped the
  re-seeding half. PreserveAndReconcile targets fed by replayable async projections
  are equally affected. No catalog-path test pins post-promotion non-redelivery.
  EP-5 (plan 258) was added for this on 2026-08-13 and gates the release like its
  siblings.
- EP-2 established the final 0.12 replay evidence baseline as `contract-v4:` plus
  `keiro/projection-replay/v4`. Resume is contract-scoped and pins adapter application
  order; abandon is slice-scoped and returns `CatalogRebuildSliceMismatch` for real group
  drift. EP-3 must build its `'$pre-canonical'` recovery semantics against these values
  and the new abandon error boundary rather than the retired v3 contract.
- EP-3 established the lifecycle boundary EP-4 must preserve while reshaping adoption
  reports: adoption may act on `live` groups or `failed` groups with a stale-format slice,
  never on `rebuilding` or canonical-format failed groups, and it never removes the
  failed fence. Sentinel run inspection is independent of current catalog membership;
  the adoption scope/report work must not reintroduce a catalog lookup ahead of it.


## Decision Log

- Decision: Split the two Runner.hs replay defects into separate plans (EP-1 pager
  behavior, EP-2 persisted contract) instead of one combined replay plan.
  Rationale: independent verifiability — an in-memory ordering proof versus a
  resume-refusal proof — and a behavior fix should not be coupled to a persisted-format
  change that requires an ADR-32 prefix bump.
  Date: 2026-08-12
- Decision: Merge the adoption preview/scope mismatch and the UPDATE-only silent no-op
  findings into one plan (EP-4).
  Rationale: both are defects of the same adoption transaction and its report; fixing
  either reshapes the same preview/result types, so two plans would have to modify the
  same functions in the same way — the specification's signal for merging.
  Date: 2026-08-12
- Decision: Keep the 0024 `'$pre-canonical'` recovery as its own plan (EP-3) and require
  it to ship as a library API wrapped by keiro-ops, never as documented remediation SQL.
  Rationale: ADR-32 explicitly promised a supported clean-break path pre-0.12, and
  ADR-28 forbids operator remedies that bypass supported APIs.
  Date: 2026-08-12
- Decision: All four plans gate the 0.12.0.0 tag.
  Rationale: the persisted run/contract formats and the adoption surface become
  compatibility promises at the first stable release; the project's release bar is that
  no known bugs ship.
  Date: 2026-08-12
- Decision: Added EP-5 (plan 258, async redelivery safety at promotion) after the
  observation flagged during plan-256 drafting was adversarially confirmed; it gates
  the release, and its backfill/advance helpers are the shared implementation plan
  256 reuses for the versioned path.
  Rationale: a confirmed silent double-application defect meets the same bar as the
  review's original findings; fixing it in the offline protocol first gives the
  versioned protocol a proven primitive instead of two divergent implementations.
  Date: 2026-08-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

- EP-1 completed on 2026-08-13. Multi-source buffered replay now clamps each merged chunk
  to the smallest unexhausted source horizon and enforces a monotonic applied-position
  floor. The exact regression and 18-case deterministic sweep pass, source-read counts are
  unchanged, the benchmark delta is within noise, and `just verify` exits 0. The fix
  changes no public API or persisted contract, so the ADR distillation pass required no
  ADR amendment and EP-2 retains sole ownership of the planned contract-prefix change.
- EP-2 completed on 2026-08-12. Rebuild contracts and runner evidence now use v4 and
  include replay-adapter identities in application order, so an interrupted run cannot
  silently mix declaration orders. Four database-backed proofs cover refusal, unchanged
  resume, order-compatible registration/abandon, and observable application order;
  `just verify` passes. Abandonment is deliberately slice-scoped, and the durable
  identity/cutover boundary is recorded in ADR-32 for EP-3 and MasterPlan 41 to consume.
- EP-3 completed on 2026-08-13. Migration 0024's exact stranded shape is pinned, and
  `$pre-canonical` runs now support inspection and safe active-run abandonment while
  refusing resume, terminal abandonment, and replaced-run abandonment. Failed
  stale-format groups can be adopted without lifting their fence, then rebuilt freshly
  through the new failed -> rebuilding transition. The supported ops transcript,
  startup registration, fresh promotion, documentation, changelogs, ADR-26/ADR-32, and
  the full `just verify` gate all pass; operators no longer need SQL remediation.

(Overall MasterPlan retrospective to be completed after the remaining child plans.)
