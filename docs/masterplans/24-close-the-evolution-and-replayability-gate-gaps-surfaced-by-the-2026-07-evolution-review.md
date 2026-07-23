---
id: 24
slug: close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review
title: "Close the evolution and replayability gate gaps surfaced by the 2026-07 evolution review"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
intention: intention_01ky7q57fbevsszaj32g77f6vt
---

# Close the evolution and replayability gate gaps surfaced by the 2026-07 evolution review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The July 2026 evolution review mapped, with adversarial verification, what happens to a deployed keiro service when its commands, events, and transducers change over the application's lifetime. The architectural ground truth: keiki has no separate decide/evolve — one edge set is both forward execution and replay (replay re-inverts each stored event to a command and re-checks the edge guard), so editing guards, outputs, or updates edits the interpretation of the existing log; upcasters run at decode-time forever; and there is no stored-data migration story. The companion developer guide (`docs/guides/evolution-and-replayability.md`, authored with this MasterPlan) prescribes the safe procedure per change class. This MasterPlan closes the verified gate gaps — the evolution mistakes that today pass `keiro-dsl check`, `diff`, the harness, and `mkEventStreamOrThrow`, and detonate in production.

Four confirmed unsoundnesses anchor it. (1) Stale snapshots on fold change — the worst gap in the stack: the snapshot discriminator is `(state_codec_version, regfile_shape_hash)`, and the shape hash covers register slot names/canonical type names/order only — not fold logic, not the control-state type, not slot-type internals. Changing an edge's `update` and deploying serves old-fold snapshots as seeds, silently; worse, the post-append replay witness then re-persists the stale-derived state as a fresh snapshot at the new head version, compounding it; `snapshots.md` actively misdirects (its claim that state-shape changes update the hash is false). (2) Deprecated ≠ replayable: with an event's emitting transition removed, hydration of any live stream containing it fails `HydrationNoInvertingEdge`; the DSL validator forbids emitting deprecated events, `diff` calls deprecation ADDITIVE and even recommends the unsound path in its message, and no gate sees transition removal at all — the deploy passes everything and the first command on an affected stream fails. The safe landed path is now two-stage: keep the live emitter while `retiring`, then cut over to `deprecated` plus an equivalent `replay-only` emitter; the keep-transition-drop-emit half-measure remains loudly refused by `StateChangingEpsilon`. (3) The codec is never validated at the stream boundary: `mkCodec` — which catches duplicate tags, duplicate upcaster rungs, and chain gaps — has zero production call sites, and verification found two *reachable* DSL evolutions that generate mkCodec-rejectable codecs: two events bumped in one release yield duplicate rungs (first match wins, the other upcaster silently never runs), and sequential bumps across releases vanish a rung (every v1-stamped payload then fails `GapInUpcasterChain` at hydration). (4) The DSL's upcaster lowering discards the event-type tag (`const`) while stamping schema versions aggregate-globally, so a version-m upcaster receives every event kind's payload stored at m; the common failure is loud, but overlapping field names turn it into silent value corruption, and the generated harness only ever feeds the declaring event's own current-shape payload through the chain. Supporting gaps from the review: the versioned `keiroJobCodec` (plan 55) was never adopted — the DSL scaffolds unversioned job codecs; deterministic router/PM dispatch ids silently dedupe half-old/half-new fan-out across a decide-change redelivery window; and four user docs carry evolution-relevant drift.

After this initiative: a fold change cannot silently serve stale snapshots (the discriminator gains a fold-sensitive component, with a diff advisory as the interim); deprecating an event that live streams still contain is refused or guided to the safe pattern; `mkEventStream` validates the codec so chain gaps and duplicate rungs fail at startup, with DSL validator rules preventing their generation; upcasters receive the wire tag and the harness proves genuine old payloads decode; scaffolded pgmq jobs get versioned codecs; the evolution docs say true things, including the deploy-ordering rules that exist nowhere today; and — the closing gate, added 2026-07-23 — a read-only, **differential replay audit**: `diff` first proves a deploy replay-neutral (no old edge or decode surface changed — most deploys, zero data touched) or names the affected event types; only streams containing those types are replayed through the candidate binary against a real database (cost proportional to the change, never a store-wide scan — production categories hold tens of millions of events); a full sweep exists solely as the opt-in mode for one-time keiki-runtime cutovers; and a sampled runtime witness compares snapshot-seeded state against full replay on a small fraction of live hydrations, so even fold changes no fingerprint can see (hole bodies, hand-written code with a missed manual bump) surface as an alertable metric. `diff` advisories additionally flag router/process decide-surface and timer-payload changes at the moment they are made. In scope: the tooling-gap table's items 1-3, 5-7, 9, 11-12 (renumbered into the child plans), the DSL codec-generation fixes, the documentation corrections, and the pre-deploy replay audit plus decide-surface advisories (EP-5). Out of scope: WFX-4/patch-at-rotation (MasterPlan 16 EP-4 owns it); resurrection (same); cross-repo producer/consumer contract conformance checking (a future initiative — the guide documents the manual rules); a *synthetic* old-log CI harness beyond golden fixtures (the database-backed replay audit is EP-5's commitment; generated-fixture CI harnessing remains follow-on).

**Exit criterion (added 2026-07-23 — the fleet-migration bar).** A keiki transducer serves exactly two durable-state uses: an aggregate handling commands, and a process manager's saga handling actions — and PM actions advance saga state through the same `runCommandWithSql` → `hydrate` path as aggregate commands (`keiro/src/Keiro/ProcessManager.hs:183-194,471-477`), so every aggregate-level gate covers process-manager state by construction. After all six child plans land, no transducer change class can silently leave a service unable to reconstruct correct register state from its stored log: each class is either refused or warned at `check`/`diff`, failed loudly at stream construction, proved replay-neutral or caught pre-deploy by the differential replay audit over the affected data, or detected by the sampled runtime seed-verification witness. The named exclusions are separately owned or non-silent: workflow journal evolution (MasterPlan 16, docs/plans/115; step-rename/patch discipline per the guide), cross-repo contract conformance (future initiative; consumer failures are loud dead letters), and hole-only decide changes over redelivery windows (a fan-out hazard, not a state-reconstruction one; covered by the drain rule plus EP-5's advisories).


## Decomposition Strategy

Six child plans. EP-1 (plan 138) owns snapshot staleness: a fold-sensitive discriminator component (design decision: a transducer fingerprint from the DSL spec's transition/writes surface where specs exist, plus the manual `stateCodecVersion` contract for hand-written services; hashing the control-state type's generic shape into `defaultStateCodec` closes the class-F silent variant), the diff advisory on any transition `writes`/guard change, and the `snapshots.md` correction. EP-2 (plan 139) owns boundary replayability gates: call `mkCodec` inside `validateEventStreamWith`; a validator/diff rule making deprecation of an event whose aggregate is non-terminal a warning/error with the safe-pattern guidance; DSL validator rules for duplicate upcaster sources and aggregate-level chain continuity across releases; and the versioned old-payload fixture convention with direct `decodeRaw` conformance coverage. EP-3 (plan 140) owns DSL codec-generation fidelity: each aggregate upcaster rung dispatches on `EventType` before calling the event-specific, `Value`-only hole, so foreign kinds pass through automatically; harness upcast assertions run genuine serialized old payloads; and the scaffolder emits `keiroJobCodec`-backed job codecs (closing the plan-63-recorded gap). EP-4 (plan 141) owns documentation truth: fix the four drifted docs (snapshots.md's false hash claim, codecs-and-event-evolution.md's pre-EventType signatures and missing error constructors, evolve-events-safely.md's arity, missing `Custom`/`Terminality`), add the deploy-ordering rules (roll-forward-only aggregate bumps; workers-before-producers generalized; drain-before-deploy for decide changes over PM/router redelivery windows; the replay audit as the standard pre-deploy gate once EP-5 lands), and cross-link the new guide. EP-5 (plan 142, added 2026-07-23) owns the closing gate, designed differential because production stores are tens of millions of events: a `diff` replay-impact verdict (replay-neutral proof or the conservative affected event-type set), the read-only audit (`Keiro.ReplayAudit` over `Keiro.Command`'s newly exported hydrate primitives — targeted mode replays only streams containing affected types; full mode is the opt-in one-time-cutover sweep; seeded-vs-full state comparison catches stale seeds; per-stream digests make any reinterpretation reviewable across binaries), a sampled runtime seed-verification witness for the fold changes nothing can see at deploy time, the generated per-context wiring (`Generated/<Ctx>/ReplayAudit.hs`), the jitsurei reference assembly, and the router/process decide-surface and timer-payload `diff` advisories the companion guide promised to this MasterPlan. EP-6 (plan 143, added 2026-07-23) owns the *remedy* for the one change class where detection alone leaves the developer without a good move — guard tightening breaking inversion of history (the "black-acuity" case): a keiki-native `ReplayOnly` edge mode (included in inversion, excluded from forward stepping, exempt from dead-edge reachability, still ambiguity-checked), a DSL `replay-only transition` marker lowering to it, and a diff advisory that *computes and prints* the paste-ready replay-only twin (`old-guard ∧ ¬new-guard`) whenever a guard tightens; it supersedes EP-2's guarded-but-inert contortion as the sanctioned retained-edge shape.

Alternatives considered. Folding EP-4 into the guide authoring was rejected: the guide is a new document shipped with this MasterPlan's creation; EP-4 edits existing documents and must track EP-1-3's shipped shapes. Implementing the old-log compatibility harness (tooling gap 4) as a full EP was originally rejected as premature in favour of EP-2's golden fixtures; the 2026-07-23 completeness audit reversed that in database-backed form (see Decision Log) — golden fixtures prove decode-ability of old shapes only, and no gate proved replay-ability of real logs — so EP-5 commits the DB-backed audit while the synthetic generated-fixture harness stays follow-on.

ADR context: ADR 0001 (pgmq telemetry) is tangentially relevant to EP-3's job-codec change; ADR 0002 records replay-only edges; ADR 0003 records the snapshot discriminator; ADR 0004 is the evolution-gate inventory, includes EP-3's landed contracts, and must be extended again as EP-5 lands.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Gate snapshot staleness on fold changes | docs/plans/138-gate-snapshot-staleness-on-fold-changes.md | None | None | Complete |
| 2 | Validate codecs and deprecated-event replayability at the stream boundary | docs/plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md | None | None | Complete |
| 3 | Fix DSL upcaster lowering and adopt versioned job codecs | docs/plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md | None | EP-2 | Complete |
| 4 | Correct the evolution documentation and deploy-ordering guidance | docs/plans/141-correct-the-evolution-documentation-and-deploy-ordering-guidance.md | None | EP-1, EP-2, EP-3, EP-5 | Not Started |
| 5 | Add a pre-deploy replay audit and decide-surface change advisories | docs/plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md | None | EP-1, EP-2, EP-3 | Not Started |
| 6 | Add first-class replay-only transitions for guard evolution | docs/plans/143-add-first-class-replay-only-transitions-for-guard-evolution.md | None | EP-1, EP-2, EP-5 | Complete (residuals: keiki release, EP-5 audit assertions) |


## Dependency Graph

EP-1, EP-2, EP-3, EP-5 are mutually independent in hard-dependency terms and can run in parallel; EP-3 is soft-dependent on EP-2 only where its harness fixtures want the new validator rules to exist first (it can land them behind the current validator and re-run). EP-5 is soft-dependent on EP-1 (it reuses EP-1's stale-fold test scenario and its seed comparison is the detection backstop for EP-1's documented manual-contract residual — valid with either the two- or three-component discriminator, so land order is free) and on EP-2/EP-3 only through the shared `Diff.hs`/`Scaffold.hs` files and once-per-landed-plan conformance regeneration. EP-6 is soft-dependent on EP-1 (they share the transition-surface advisory and the fold-fingerprint rendering, and both carry keiki release work — one release train if concurrent), EP-2 (retained-edge wording reconciliation, in whichever lands second), and EP-5 (the audit is the checker for "does stored data exercise the removed region" and the prover for the twin-deletion endgame; EP-6's audit-based test assertions activate when both are landed). EP-4 is soft-dependent on all of EP-1/2/3/5: it documents shipped behavior; sections covering unlanded gates reference the plans by path (the deploy-ordering page names the replay audit as the standard pre-deploy gate once EP-5 lands, and the decide-change rule names `replay-only` as the remedy once EP-6 lands; EP-6 ships its own guide edits). EP-2's `mkCodec`-at-boundary change and EP-3's generated-codec changes interact: generated codecs must pass the new boundary validation — EP-3's conformance suites are the acceptance for both; land EP-2's boundary check first in CI order or gate it on the regenerated fixtures (record the choice in both Decision Logs).


## Integration Points

`keiro-core/src/Keiro/EventStream/Validate.hs` and `Keiro/Codec.hs`: EP-2 owns both; EP-1's discriminator work touches `Keiro/Snapshot/Codec.hs` and `keiki`'s shape surface (if the control-state hash lands in keiki, EP-1 states the keiki version bump; keiki changes follow the MasterPlan 9 upstream-in-scope precedent).

`keiro-dsl/src/Keiro/Dsl/{Scaffold,Validate,Diff,Harness}.hs`: EP-1 (diff advisory), EP-2 (validator rules, diff deprecation rule), EP-3 (scaffolder lowering + harness), EP-5 (audit-target emission, decide-surface diff rules) — five plans in one package: EP-3 owns Harness, the Scaffold edits are split (EP-1: `stateCodecExpr` only; EP-3: upcaster lowering + workqueue; EP-5: the new `ReplayAudit.hs` emission function; EP-6: the transition-lowering mode argument), EP-2 owns Validate (EP-1/EP-5/EP-6 add append-only `DiagnosticCode` constructors), and the Diff edits are split (EP-1: transition-writes advisory — whose detail text EP-6 extends with the computed replay-only twin; EP-2: deprecation + upcaster-chain rules; EP-5: router/process decide-surface + timer-payload advisories) — each plan names its exact rule additions to avoid merge collisions; conformance fixtures regenerate once per landed plan. keiki upstream work rides in EP-1 (state-shape hash, PVP-minor) and EP-6 (`EdgeMode`, PVP-major) — coordinate as one release train when concurrent.

`keiro/src/Keiro/ReplayAudit.hs` (new) and `Keiro.Command`'s hydrate-primitive exports: EP-5 owns both. EP-1 edits the same package's snapshot path (`Snapshot.hs`, `Snapshot/Schema.hs`, `Snapshot/Codec.hs`); EP-5's `Command.hs` change is an append-only export-list addition, so rebases stay textual-conflict-free. EP-5's stale-seed detection deliberately reuses EP-1's stale-fold test scenario as its second acceptance example — the two plans assert opposite halves of the same contract (EP-1: the discriminator refuses what it can see; EP-5: the audit detects what the discriminator cannot).

Generated-code compatibility: every scaffolder/codec change regenerates the checked-in conformance fixtures; the 24-suite green bar from MasterPlan 15 is the shared acceptance floor.

`docs/user/` and `docs/guides/`: EP-4 owns all evolution-doc edits; EP-1-3 record their externally visible contracts in Decision Logs for EP-4 to quote (same convention as MasterPlan 18).

Cross-plan decision for ADR promotion: the snapshot-discriminator contract; the evolution-gate inventory table (which the guide summarizes and the ADR fixes as the durable record).


## Progress

- [x] EP-1 (2026-07-23): Fold-sensitive snapshot discriminator shipped (DSL fingerprint + state-shape hash + documented manual contract); stale-fold test fails before, passes after.
- [x] EP-1 (2026-07-23): Diff advisory on transition writes/guard changes; snapshots.md corrected; ADR 0003 records the durable contract.
- [x] EP-2 (2026-07-23): `mkCodec` runs at the stream boundary; duplicate-rung and vanished-rung evolutions fail at startup and are refused by new validator rules.
- [x] EP-2 (2026-07-23): Two-stage retirement (`retiring`, then `deprecated` plus replay-only) is checked/advised; diff no longer recommends decode-only deprecation; versioned old-payload goldens decode through `decodeRaw` in CI.
- [x] EP-3 (2026-07-23): Generated rungs dispatch on the wire tag into event-specific holes and pass foreign kinds through; genuine old payloads run in the harness; scaffolded workqueues emit versioned job codecs.
- [ ] EP-4: Four drifted docs corrected; deploy-ordering rules documented (including the replay audit as the standard pre-deploy gate); guide cross-linked.
- [ ] EP-5: Replay audit library and generated per-context wiring shipped; the no-inverting-edge and stale-seed scenarios are caught against a real store pre-deploy; digests stable across runs.
- [ ] EP-5: Router/process decide-surface and timer-payload diff advisories fire on fixture pairs with drain-before-deploy guidance; jitsurei reference assembly added.
- [x] EP-6 (2026-07-23): keiki `EdgeMode` landed (forward-excluded, two-phase inversion-included, dead-edge-clean without a reachability change, same-mode ambiguity-checked; keiki 0.3.0.0, commit `a8d6377`); black-acuity regression green with a replay-only twin and red without (keiro `48ef795`).
- [x] EP-6 (2026-07-23): DSL `replay-only` marker round-trips and lowers to `B.replayOnly`; the `AggGuardTightened` advisory prints the paste-ready computed twin (`complementExpr`); guide/adoption-doc procedures in present tense (keiro `101f549`; ADR 0002). Residuals tracked in plan 143: keiki 0.3.0.0 release publication, and the plan-142 audit assertions over the divert store.


## Surprises & Discoveries

- Verification (2026-07-23): the stale-snapshot gap is worse than the review stated — `verifyAndSnapshot` re-persists stale-derived state as a fresh snapshot at the new head version, so the full-replay escape hatch recedes with every command.
- Verification (2026-07-23): two previously unknown, reachable DSL codec-generation bugs found while refuting claim 3 (duplicate upcaster rungs when two events bump in one release — first match wins, one upcaster silently dead; vanished rung across sequential single-step bumps — `GapInUpcasterChain` at hydration despite both diffs reporting ADDITIVE).
- Verification (2026-07-23): the deprecation variant that keeps the transition but drops its emit is caught loudly at startup by the forced `StateChangingEpsilon` check — the half-measure cannot ship; transition-removal and replacement-event variants were the paths that passed every pre-EP-2 gate.
- Verification (2026-07-23): claim 4's failure gradation — unfilled/strict upcasters fail loudly at hydration; purely-additive upcasters are benign for other kinds; silent value corruption requires overlapping field names between event kinds at the same stored version.
- Guide authoring (2026-07-23), resolved by EP-2 after EP-6 landed first: `retiring event` records the pre-cutover phase and requires the live emitter; `deprecated event` plus an equivalent `replay-only` emitter is the safe cutover. `DeprecatedEventStillEmitted` continues to forbid live writes only, so its meaning stayed sharp.
- Guide authoring (2026-07-23), affects EP-4: aggregate codec version bumps are not rolling-deploy-safe at all — `Keiro.Codec` cannot decode vN while still writing vN-1 (`VersionAhead`), so old replicas fail hydration during the rollout window; EP-4 (docs/plans/141) documents stop-the-world/blue-green for aggregate bumps, with a two-phase decode-then-write capability recorded as future work.
- Plan authoring (2026-07-23), affects EP-3: the "scaffolder emits a literal unversioned JobCodec" premise was inexact — plan 63's promised generated job codec never landed at all (the unversioned `mkJobCodec` assembly lives in hand-owned fixtures); EP-3 (docs/plans/140) therefore adds a new generated `QueueCodec` module rather than replacing an existing emission.
- Plan authoring (2026-07-23), affects EP-2 (analysis-level, not review-verified): a deeper stamp-collision hazard — with aggregate-global version stamps, bumping a second event to its *own* previous+1 (below the aggregate max) leaves its old-shape payloads stamped current and permanently unmigrated, worse than the verified duplicate-rung symptom; embedded as the rationale for EP-2's aggregate-max+1 versioning guidance.
- Completeness audit (2026-07-23), grounds EP-5: a process manager's durable state is an ordinary aggregate — the saga aggregate — advanced through the identical `runCommandWithSql` → `hydrate` path (`keiro/src/Keiro/ProcessManager.hs:183-194,471-477`; DSL `process` nodes reference it via `SagaRef`, `keiro-dsl/src/Keiro/Dsl/Grammar.hs:438-446,559-575`, and declare no events or snapshot block of their own). So EP-1-3's aggregate-keyed gates cover PM state *transitively*, and the exit criterion can be stated for both transducer uses without widening those plans. Routers are stateless (no stream, no snapshot); workflow journals use a separate fixed codec (`workflowJournalCodec`, `keiro/src/Keiro/Workflow/Types.hs:204-223`; sentinel-hash `workflowStateCodec`, `keiro/src/Keiro/Workflow/Snapshot.hs:64-93`) outside every EP-1-3 gate — owned by MasterPlan 16's discipline, not this initiative.
- Completeness audit (2026-07-23), fixed by EP-5: two promises the companion guide made on this MasterPlan's behalf were unassigned — the process/router mapping-change `diff` advisory ("in scope for masterplan 24"), which no child plan implemented (`routerPairDiff` never inspects `rtResolve`/`rtDispatch`, `keiro-dsl/src/Keiro/Dsl/Diff.hs:232-248`; `processPairDiff` skips the `handle` surface and the timer `payload` block, `Diff.hs:810-869`), and old-log guard compatibility ("golden replay fixtures … captured as part of docs/plans/139"), which EP-2's goldens do not actually deliver — they exercise `decodeRaw` only, proving decode-ability, never inversion or guard re-check against stored histories. Both now live in EP-5 (plan 142), and the guide's pointers were corrected in the same revision.
- Completeness audit (2026-07-23): the silent-shift variant of a decide-surface edit — a guard/output change that makes a stored event invert *unambiguously to a different edge*, so replay succeeds with different register writes and no error — is undetectable by any static or startup gate even in principle (there is no oracle for "which interpretation was intended"). EP-5's digest mode is the answer: run the audit under the deployed binary and the candidate, diff the per-stream digests, and every reinterpretation — intended or not — becomes a reviewable line.
- EP-1 completion (2026-07-23): Hackage serves keiki, keiki-codec-json, and keiki-codec-json-test 0.3.1.0; after refreshing Cabal to index state `2026-07-23T15:51:41Z`, keiro built and passed its full plan-138 acceptance bar without the local dependency overlay. The upstream v0.3.1.0 tag remains a maintainer-owned release-administration follow-up; it does not block dependency resolution or EP-1's shipped behavior.
- EP-2 completion (2026-07-23): the first full DSL bar found `retiring` could be swallowed as a state name when no command preceded the event; QuickCheck seed 180655211 pinned the ambiguity. Reserving the marker fixed that seed, after which all 24 DSL suites, 227 unit examples, and the v1 `decodeRaw` golden passed. The mutation check proved removing the upcaster fails the golden.
- EP-3 completion audit (2026-07-23): the hurried partial implementation could not compile because generated `QueueCodec` exported `reservation_workJobCodec` while consumers imported `reservationWorkJobCodec`, and the fresh-skeleton fixture omitted the new generated module. Lower-camel normalization and complete fixture/Cabal wiring repaired both. The audit also corrected an inaccurate real-database acceptance claim: the existing queue suites are pure, so they now pin the exact `{v,t,data}` `JobCodec` boundary and compile it into live `Job` values instead.


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

- Decision: The MasterPlan adopts an explicit exit criterion (stated in Vision & Scope): after all six child plans land, no transducer change class — for either keiki use, aggregate commands or process-manager actions — can silently break register-state reconstruction from the stored log; every class is refused/warned pre-merge, failed loudly at startup, or caught pre-deploy by the replay audit against real data.
  Rationale: This initiative is the gate for switching all microservices to the keiki runtime; a registry of fixes without a completeness bar cannot certify that switch. The 2026-07-23 completeness audit (Surprises) verified the coverage map: PM state is transitively covered because saga state is an aggregate; the two failure classes no existing child closed (old-log inversion breakage/shift; stale seeds from missed manual bumps) are exactly what EP-5's audit detects. The exclusions are enumerated in the same paragraph so the guarantee is checkable, not aspirational.
  Date: 2026-07-23

- Decision: EP-5 (plan 142) is added: a database-backed, read-only replay audit (full replay + seeded-vs-full comparison + per-stream digests) plus the decide-surface/timer-payload diff advisories; the original "old-log harness is premature" deferral is reversed in this form only.
  Rationale: Whether a stored event still inverts depends on each stream's actual history — no synthesized fixture set enumerates it, so a synthetic CI harness stays follow-on while the audit against real data becomes the commitment. The audit also converts EP-1's documented manual-contract residual (hand-written/Holes-only fold changes) from "silent, accepted" to "detectable pre-deploy", which the exit criterion requires. The advisories close the guide's unassigned promise at the correct layer (Advisory, drain-procedure text), since the redelivery-window hazard is temporal and cannot be refused statically.
  Date: 2026-07-23

- Decision: EP-5's audit is differential and budget-bounded — never a routine full-store replay. `diff` proves replay-neutrality (no retained edge's guard/writes/output surface and no decode surface changed → stored-data replay is bitwise identical by construction, no audit needed) or emits the conservative affected event-type set; the audit replays only streams containing affected types; `AuditFull` is reserved for one-time keiki-runtime cutovers and forensics; and the stale-seed residual is covered by a sampled runtime witness (a fraction of snapshot-seeded hydrations asynchronously full-replay and compare, emitting a divergence metric) instead of scheduled sweeps.
  Rationale: User constraint (2026-07-23): production event stores hold tens of millions of events, so a store-wide pre-deploy replay is not a realistic routine gate. The differential design keeps the exit criterion sound: the neutrality proof covers the common additive deploy with zero data cost; a non-neutral change can only affect streams containing the changed edges' event types, so the targeted audit's cost is proportional to the change; and the sampled witness converges fleet-wide within hours for the one class with no deploy-time trigger at all. The one-time full sweep aligns with the migration plan — moving an existing service onto the keiki runtime already has a cutover window, which is the single proportionate moment for store-wide certainty.
  Date: 2026-07-23

- Decision: EP-6 (plan 143) is added: first-class replay-only transitions — a keiki `EdgeMode` (inversion-included, forward-excluded), a DSL `replay-only transition` marker, and a diff advisory that computes and prints the removed-region twin on guard tightening.
  Rationale: The user's adoption review (2026-07-23) surfaced that guard tightening is the one change class where the initiative previously offered detection (EP-1 advisory, EP-5 verdict + audit) but no first-class *remedy* — the sanctioned pattern was EP-2's guarded-but-inert phantom-flag contortion. Verified against keiki source that the fix is small and principled: inversion is solve-then-check over `edgesOut` (`keiki/src/Keiki/Core.hs:1222-1229`), and both engine paths share single choke points, so an edge mode filtered from forward stepping but visible to inversion delivers "the tightened rule governs the future, history keeps its inverting edge" — the classic decide/evolve virtue without its silent-drift vice, and a competitive answer to the tan-event-source objection documented in `docs/guides/adopting-keiro-from-tan-event-source.md`.
  Date: 2026-07-23

- Decision: A runtime cross-version dispatch witness (decide-fingerprint stamped on dispatched commands, flagged on benign-duplicate confirmation across versions) is recorded as a follow-on candidate, not scoped into EP-5.
  Rationale: It touches the Router dedupe path MasterPlan 14 hardened and adds a read per duplicate confirmation; the drain rule plus EP-5's advisories cover the hazard procedurally. Revisit if fleet telemetry shows drain discipline failing.
  Date: 2026-07-23

- Decision: Evolution gates fail at the earliest boundary with enough evidence, and later
  boundaries independently defend runtime assembly: single-spec impossibilities are
  Errors from `check`, cross-version hazards are classified by `diff`, constructed codecs
  are revalidated by `mkCodec` inside `validateEventStreamWith`, and old payload fixtures
  exercise `decodeRaw`. ADR 0004 records the inventory and its remaining EP-5 rows.
  Rationale: No one layer has all necessary evidence, and generated code is not the only
  way to construct a stream. Layering the gates prevents both false certainty and a
  generator-only safety claim.
  Date: 2026-07-23

- Decision: Generated aggregate upcaster holes remain event-specific
  `Value -> Either Text Value` functions; one generated dispatcher per schema rung owns
  the `EventType` case split and passes foreign kinds through. Same-source upcasts for
  distinct events are therefore legal and merge into one rung. Old-shape goldens are
  emitted write-once during `diff`, embedded by `scaffold`, and exercised with
  `decodeRaw`; scaffolded workqueues receive schema-v1 `keiroJobCodec` adapters, whose
  adoption on non-empty bare-payload queues requires a drain or transitional codec.
  Rationale: EP-3's audited implementation makes tag routing automatic, preserves small
  hole APIs, turns old-wire compatibility into a self-contained harness assertion, and
  establishes an evolution envelope for fresh queues without changing ADR 0001's job
  telemetry semantics. ADR 0004 holds the durable gate inventory.
  Date: 2026-07-23


## Outcomes & Retrospective

- EP-1, EP-2, and EP-3 are complete. EP-2 closed the codec-construction gap, refuses the two
  reachable poisoned DSL shapes, made event retirement an explicit two-stage protocol,
  corrected diff classifications, and established the versioned old-payload golden
  convention. EP-3 now lowers same-source event upcasts into a safe tag dispatcher,
  embeds genuine old-payload goldens in generated harnesses, and emits versioned queue
  codecs. The remaining initiative work is EP-4 (documentation truth) and EP-5
  (real-log replay audit and decide advisories).


---

Revision note (2026-07-23, EP-2 closeout): plan 139 completed. Registry and both EP-2
progress rows are complete; replay-only reconciliation replaced the earlier
guarded-but-inert retirement wording; ADR 0004 now records the layered evolution-gate
inventory and its EP-3/EP-5 extensions.

Revision note (2026-07-23, EP-3 closeout): plan 140 completed after an audit of the
hurried partial implementation. Registry and EP-3 progress are complete; Decomposition
now records the generated-dispatch decision instead of the rejected tag-taking-hole
shape; ADR 0004 records the dispatch, write-once golden, and generated queue-codec
contracts; and the remaining initiative work is EP-4 and EP-5.

Revision note (2026-07-23, third pass): Added EP-6 (docs/plans/143 — first-class `replay-only` transitions) after the adoption review pressed on the black-acuity example: detection without a remedy left guard tightening as a landmine, and the guarded-but-inert pattern was a hack. Also authored `docs/guides/adopting-keiro-from-tan-event-source.md` (engineer-facing comparison against the legacy decide/evolve framework, with tan-ES code citations) under this MasterPlan. Registry, Decomposition, Dependency Graph, Integration Points (Scaffold/Diff splits now five-way; keiki release-train note), Progress, and the evolution guide's decide-change section updated together.

Revision note (2026-07-23, second pass): EP-5's audit redesigned from "replay every live stream pre-deploy" to the differential/tiered form after the user flagged the scale constraint (stores hold tens of millions of events): replay-impact verdict at diff time, targeted audit over the affected event-type set only, full sweep reserved for one-time cutovers, and a sampled runtime seed-verification witness replacing any scheduled sweep for the manual-bump residual. Plan 142, this MasterPlan's Vision/Decomposition/Decision Log, and the guide's deploy-ordering bullet updated together.

Revision note (2026-07-23): Update pass driven by the fleet-migration completeness question — "after this MasterPlan, can any change to a keiki transducer (aggregate commands or process-manager actions) still silently break register-state reconstruction or replay?" A code-verified audit (Surprises & Discoveries, "Completeness audit" entries) confirmed PM state is transitively covered by the aggregate gates, and found two unclosed classes plus two unassigned guide promises. Changes: added EP-5 (docs/plans/142 — pre-deploy replay audit + decide-surface/timer-payload diff advisories); added the explicit exit criterion to Vision & Scope; updated Decomposition Strategy, Registry (EP-4 gains soft-dep EP-5), Dependency Graph, Integration Points (four-way Scaffold/Diff splits; keiro audit-module ownership), and Progress; corrected the companion guide's stale pointers (decide-surface advisory and old-log replay gate now cite plan 142); cascaded cross-references into plans 138, 139, and 141.
