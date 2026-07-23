---
id: 24
slug: close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review
title: "Close the evolution and replayability gate gaps surfaced by the 2026-07 evolution review"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
---

# Close the evolution and replayability gate gaps surfaced by the 2026-07 evolution review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The July 2026 evolution review mapped, with adversarial verification, what happens to a deployed keiro service when its commands, events, and transducers change over the application's lifetime. The architectural ground truth: keiki has no separate decide/evolve — one edge set is both forward execution and replay (replay re-inverts each stored event to a command and re-checks the edge guard), so editing guards, outputs, or updates edits the interpretation of the existing log; upcasters run at decode-time forever; and there is no stored-data migration story. The companion developer guide (`docs/guides/evolution-and-replayability.md`, authored with this MasterPlan) prescribes the safe procedure per change class. This MasterPlan closes the verified gate gaps — the evolution mistakes that today pass `keiro-dsl check`, `diff`, the harness, and `mkEventStreamOrThrow`, and detonate in production.

Four confirmed unsoundnesses anchor it. (1) Stale snapshots on fold change — the worst gap in the stack: the snapshot discriminator is `(state_codec_version, regfile_shape_hash)`, and the shape hash covers register slot names/canonical type names/order only — not fold logic, not the control-state type, not slot-type internals. Changing an edge's `update` and deploying serves old-fold snapshots as seeds, silently; worse, the post-append replay witness then re-persists the stale-derived state as a fresh snapshot at the new head version, compounding it; `snapshots.md` actively misdirects (its claim that state-shape changes update the hash is false). (2) Deprecated ≠ replayable: with an event's emitting transition removed, hydration of any live stream containing it fails `HydrationNoInvertingEdge`; the DSL validator forbids emitting deprecated events, `diff` calls deprecation ADDITIVE and even recommends the unsound path in its message, and no gate sees transition removal at all — the deploy passes everything and the first command on an affected stream fails. (The keep-transition-drop-emit variant is caught loudly at startup by the forced `StateChangingEpsilon` check — the guide documents it as the interim safe pattern.) (3) The codec is never validated at the stream boundary: `mkCodec` — which catches duplicate tags, duplicate upcaster rungs, and chain gaps — has zero production call sites, and verification found two *reachable* DSL evolutions that generate mkCodec-rejectable codecs: two events bumped in one release yield duplicate rungs (first match wins, the other upcaster silently never runs), and sequential bumps across releases vanish a rung (every v1-stamped payload then fails `GapInUpcasterChain` at hydration). (4) The DSL's upcaster lowering discards the event-type tag (`const`) while stamping schema versions aggregate-globally, so a version-m upcaster receives every event kind's payload stored at m; the common failure is loud, but overlapping field names turn it into silent value corruption, and the generated harness only ever feeds the declaring event's own current-shape payload through the chain. Supporting gaps from the review: the versioned `keiroJobCodec` (plan 55) was never adopted — the DSL scaffolds unversioned job codecs; deterministic router/PM dispatch ids silently dedupe half-old/half-new fan-out across a decide-change redelivery window; and four user docs carry evolution-relevant drift.

After this initiative: a fold change cannot silently serve stale snapshots (the discriminator gains a fold-sensitive component, with a diff advisory as the interim); deprecating an event that live streams still contain is refused or guided to the safe pattern; `mkEventStream` validates the codec so chain gaps and duplicate rungs fail at startup, with DSL validator rules preventing their generation; upcasters receive the wire tag and the harness proves genuine old payloads decode; scaffolded pgmq jobs get versioned codecs; and the evolution docs say true things, including the deploy-ordering rules that exist nowhere today. In scope: the tooling-gap table's items 1-3, 5-7, 9, 11-12 (renumbered into the child plans), the DSL codec-generation fixes, and the documentation corrections. Out of scope: WFX-4/patch-at-rotation (MasterPlan 16 EP-4 owns it); resurrection (same); cross-repo producer/consumer contract conformance checking (a future initiative — the guide documents the manual rules); an automatic old-log-vs-new-machine CI harness beyond golden fixtures (captured as a stretch inside EP-2, not a commitment).


## Decomposition Strategy

Four child plans. EP-1 (plan 138) owns snapshot staleness: a fold-sensitive discriminator component (design decision: a transducer fingerprint from the DSL spec's transition/writes surface where specs exist, plus the manual `stateCodecVersion` contract for hand-written services; hashing the control-state type's generic shape into `defaultStateCodec` closes the class-F silent variant), the diff advisory on any transition `writes`/guard change, and the `snapshots.md` correction. EP-2 (plan 139) owns boundary replayability gates: call `mkCodec` inside `validateEventStreamWith`; a validator/diff rule making deprecation of an event whose aggregate is non-terminal a warning/error with the safe-pattern guidance; DSL validator rules for duplicate upcaster sources and aggregate-level chain continuity across releases; golden old-payload fixtures generated by the harness. EP-3 (plan 140) owns DSL codec-generation fidelity: upcaster lowering passes the tag (hole signature gains `EventType`), the hole stub documents the every-kind-at-this-version contract, harness upcast assertions run genuine serialized old payloads, and the scaffolder emits `keiroJobCodec`-backed job codecs (closing the plan-63-recorded gap). EP-4 (plan 141) owns documentation truth: fix the four drifted docs (snapshots.md's false hash claim, codecs-and-event-evolution.md's pre-EventType signatures and missing error constructors, evolve-events-safely.md's arity, missing `Custom`/`Terminality`), add the deploy-ordering rules (roll-forward-only aggregate bumps; workers-before-producers generalized; drain-before-deploy for decide changes over PM/router redelivery windows), and cross-link the new guide.

Alternatives considered. Folding EP-4 into the guide authoring was rejected: the guide is a new document shipped with this MasterPlan's creation; EP-4 edits existing documents and must track EP-1-3's shipped shapes. Implementing the old-log compatibility harness (tooling gap 4) as a full EP was rejected as premature: golden fixtures in EP-2 deliver most of the value; the full generated-fixture harness is recorded as follow-on.

ADR context: `docs/adr/0001` (pgmq telemetry) is tangentially relevant to EP-3's job-codec change (must not alter span semantics); no other ADR exists. Candidate ADRs: the snapshot-discriminator contract (what invalidates a snapshot and why), and the evolution-gate inventory (which change class is caught where).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Gate snapshot staleness on fold changes | docs/plans/138-gate-snapshot-staleness-on-fold-changes.md | None | None | Not Started |
| 2 | Validate codecs and deprecated-event replayability at the stream boundary | docs/plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md | None | None | Not Started |
| 3 | Fix DSL upcaster lowering and adopt versioned job codecs | docs/plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md | None | EP-2 | Not Started |
| 4 | Correct the evolution documentation and deploy-ordering guidance | docs/plans/141-correct-the-evolution-documentation-and-deploy-ordering-guidance.md | None | EP-1, EP-2, EP-3 | Not Started |


## Dependency Graph

EP-1, EP-2, EP-3 are mutually independent (snapshot path vs boundary validation vs codegen) and can run in parallel; EP-3 is soft-dependent on EP-2 only where its harness fixtures want the new validator rules to exist first (it can land them behind the current validator and re-run). EP-4 is soft-dependent on all three: it documents shipped behavior; sections covering unlanded gates reference the plans by path. EP-2's `mkCodec`-at-boundary change and EP-3's generated-codec changes interact: generated codecs must pass the new boundary validation — EP-3's conformance suites are the acceptance for both; land EP-2's boundary check first in CI order or gate it on the regenerated fixtures (record the choice in both Decision Logs).


## Integration Points

`keiro-core/src/Keiro/EventStream/Validate.hs` and `Keiro/Codec.hs`: EP-2 owns both; EP-1's discriminator work touches `Keiro/Snapshot/Codec.hs` and `keiki`'s shape surface (if the control-state hash lands in keiki, EP-1 states the keiki version bump; keiki changes follow the MasterPlan 9 upstream-in-scope precedent).

`keiro-dsl/src/Keiro/Dsl/{Scaffold,Validate,Diff,Harness}.hs`: EP-1 (diff advisory), EP-2 (validator rules, diff deprecation rule), EP-3 (scaffolder lowering + harness) — three plans in one package: EP-3 owns Scaffold/Harness, EP-2 owns Validate, the Diff edits are split (EP-1: transition-writes advisory; EP-2: deprecation + upcaster-chain rules) — each plan names its exact rule additions to avoid merge collisions; conformance fixtures regenerate once per landed plan.

Generated-code compatibility: every scaffolder/codec change regenerates the checked-in conformance fixtures; the 24-suite green bar from MasterPlan 15 is the shared acceptance floor.

`docs/user/` and `docs/guides/`: EP-4 owns all evolution-doc edits; EP-1-3 record their externally visible contracts in Decision Logs for EP-4 to quote (same convention as MasterPlan 18).

Cross-plan decision for ADR promotion: the snapshot-discriminator contract; the evolution-gate inventory table (which the guide summarizes and the ADR fixes as the durable record).


## Progress

- [ ] EP-1: Fold-sensitive snapshot discriminator shipped (DSL fingerprint + state-shape hash + documented manual contract); stale-fold test fails before, passes after.
- [ ] EP-1: Diff advisory on transition writes/guard changes; snapshots.md corrected.
- [ ] EP-2: `mkCodec` runs at the stream boundary; duplicate-rung and vanished-rung evolutions fail at startup and are refused by new validator rules.
- [ ] EP-2: Deprecation of live-stream events refused/guided; diff message no longer recommends the unsound path; golden old-payload fixtures decode in CI.
- [ ] EP-3: Upcaster holes receive the wire tag with a documented every-kind contract; harness runs genuine old payloads; scaffolder emits versioned job codecs.
- [ ] EP-4: Four drifted docs corrected; deploy-ordering rules documented; guide cross-linked.


## Surprises & Discoveries

- Verification (2026-07-23): the stale-snapshot gap is worse than the review stated — `verifyAndSnapshot` re-persists stale-derived state as a fresh snapshot at the new head version, so the full-replay escape hatch recedes with every command.
- Verification (2026-07-23): two previously unknown, reachable DSL codec-generation bugs found while refuting claim 3 (duplicate upcaster rungs when two events bump in one release — first match wins, one upcaster silently dead; vanished rung across sequential single-step bumps — `GapInUpcasterChain` at hydration despite both diffs reporting ADDITIVE).
- Verification (2026-07-23): the deprecation variant that keeps the transition but drops its emit is caught loudly at startup by the forced `StateChangingEpsilon` check — this becomes the guide's interim safe pattern; only transition-removal and replacement-event variants pass every gate.
- Verification (2026-07-23): claim 4's failure gradation — unfilled/strict upcasters fail loudly at hydration; purely-additive upcasters are benign for other kinds; silent value corruption requires overlapping field names between event kinds at the same stored version.
- Guide authoring (2026-07-23), affects EP-2: the safe deprecation pattern is keep-the-transition-with-its-emit — but the DSL's existing `DeprecatedEventStillEmitted` error forbids exactly that configuration, so under the DSL the only currently safe move is "do not deprecate yet"; EP-2 (docs/plans/139) must reconcile with that existing error (relax it for a marked retained form or introduce a retirement-in-progress marker), and must specify the sanctioned retained-edge shape (default-on `PossiblyDeadEdge` rejects statically-unreachable retained edges at startup; guarded-but-inert edges pass).
- Guide authoring (2026-07-23), affects EP-4: aggregate codec version bumps are not rolling-deploy-safe at all — `Keiro.Codec` cannot decode vN while still writing vN-1 (`VersionAhead`), so old replicas fail hydration during the rollout window; EP-4 (docs/plans/141) documents stop-the-world/blue-green for aggregate bumps, with a two-phase decode-then-write capability recorded as future work.
- Plan authoring (2026-07-23), affects EP-3: the "scaffolder emits a literal unversioned JobCodec" premise was inexact — plan 63's promised generated job codec never landed at all (the unversioned `mkJobCodec` assembly lives in hand-owned fixtures); EP-3 (docs/plans/140) therefore adds a new generated `QueueCodec` module rather than replacing an existing emission.
- Plan authoring (2026-07-23), affects EP-2 (analysis-level, not review-verified): a deeper stamp-collision hazard — with aggregate-global version stamps, bumping a second event to its *own* previous+1 (below the aggregate max) leaves its old-shape payloads stamped current and permanently unmigrated, worse than the verified duplicate-rung symptom; embedded as the rationale for EP-2's aggregate-max+1 versioning guidance.


## Decision Log

- Decision: Ship the developer guide (`docs/guides/evolution-and-replayability.md`) with this MasterPlan's creation, ahead of the gate implementations.
  Rationale: The user asked for developer guidance now; the guide documents today's true gate coverage honestly (citing these plans for the gaps) and is updated by EP-4 as gates land.
  Date: 2026-07-23

- Decision: The fold-fingerprint design (EP-1) prefers a DSL-spec-derived fingerprint plus a keiki state-shape hash over hashing compiled code.
  Rationale: Haskell provides no stable semantic hash of a function; the spec's transition surface is the declared intent and is diffable; hand-written services keep the manual `stateCodecVersion` contract, now actually documented.
  Date: 2026-07-23

- Decision: Cross-service contract conformance (tooling gap 8) is deferred to a future initiative.
  Rationale: It requires cross-repo spec pairing infrastructure; the guide's manual producer-first/consumer-first rules cover the fleet's near-term need.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)
